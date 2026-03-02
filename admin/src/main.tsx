import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import {
  Chart as ChartJS,
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  ArcElement,
  BarElement,
  Filler,
  Legend,
  Tooltip,
} from 'chart.js'
import { chartDefaults } from './theme'
import App from './App'
import './index.css'

ChartJS.register(
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  ArcElement,
  BarElement,
  Filler,
  Legend,
  Tooltip,
)

ChartJS.defaults.color = chartDefaults.color
ChartJS.defaults.borderColor = chartDefaults.borderColor
ChartJS.defaults.font.family = chartDefaults.fontFamily
ChartJS.defaults.font.size = chartDefaults.fontSize
ChartJS.defaults.plugins.legend.labels.boxWidth = chartDefaults.legendBoxWidth

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
